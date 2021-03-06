function result = NFFT2_1D(data, x, M, c, K)
   
N=length(data);                                         % Number of input elements
    
%--- Algorithm parameters
alfa=(2-1/c)*pi-0.01;                                   % Half-size of the support of the interpolation window

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% CONSTRUCTING THE SPECTRAL WINDOW %
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

% [KK,X]=meshgrid(-K:K,x);
% M_U=round(c*X);                                          
% PP=sqrt(K.^2-(c*X-(M_U+KK)).^2);
% phi_cap=(1/pi)*sinh(alfa*PP)./PP;
% phi_cap(find(PP==0))=alfa/pi;

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% CONSTRUCTING THE SPATIAL WINDOW %
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

kk=-M/2:M/2-1;
xi=2*pi*kk/(c*M);
phi=besseli(0,K*sqrt(alfa.^2-xi.^2));
    
%%%%%%%%%%
% STEP 1 %
%%%%%%%%%%

% --- Old version
% u2=zeros(1,c*M);
% PP=mod(M_U+KK+M*c/2,c*M)+1;
% for k=1:N 
%     u2(PP(k,(-K:K)+K+1))=u2(PP(k,(-K:K)+K+1))+data(k)*phi_cap(k,(-K:K)+K+1);
% end

% --- New version
% u=zeros(1,c*M);
% for s=-M:M-1
%     for l=1:N
%         phi_cap=0;
%         if (abs(round(c*x(l))-s)<=K)
%             pp=sqrt(K.^2-(c*x(l)-s).^2);
%             phi_cap=(1/pi)*sinh(alfa*pp)./pp;
%             if pp==0 phi_cap=alfa/pi; end
%         elseif (abs(round(c*x(l))+c*M-s)<=K)
%             pp=sqrt(K.^2-(c*x(l)-s+c*M).^2);
%             phi_cap=(1/pi)*sinh(alfa*pp)./pp;
%             if pp==0 phi_cap=alfa/pi; end
%         elseif (abs(round(c*x(l))-c*M-s)<=K)
%             pp=sqrt(K.^2-(c*x(l)-s-c*M).^2);
%             phi_cap=(1/pi)*sinh(alfa*pp)./pp;
%             if pp==0 phi_cap=alfa/pi; end
%         end
%         u(s+M+1)=u(s+M+1)+data(l)*phi_cap;
%     end
% end

u = zeros(1, c * M);
for k=-c*M/2:c*M/2-1
    for l=1:N
        phi_cap=0;
        if (abs(round(c*x(l))-k)<=K)
            pp=sqrt(K.^2-(c*x(l)-k).^2);
            phi_cap=(1/pi)*sinh(alfa*pp)./pp;
            if pp==0 phi_cap=alfa/pi; end
        elseif (abs(round(c*x(l))+c*M-k)<=K)
            pp=sqrt(K.^2-(c*x(l)-k+c*M).^2);
            phi_cap=(1/pi)*sinh(alfa*pp)./pp;
            if pp==0 phi_cap=alfa/pi; end
        elseif (abs(round(c*x(l))-c*M-k)<=K)
            pp=sqrt(K.^2-(c*x(l)-k-c*M).^2);
            phi_cap=(1/pi)*sinh(alfa*pp)./pp;
            if pp==0 phi_cap=alfa/pi; end
        end
        u(k+c*M/2+1)=u(k+c*M/2+1)+data(l)*phi_cap;
    end
end

%%%%%%%%%%
% STEP 2 %
%%%%%%%%%%

% FFT_Mc=pi/xsi_max*M*c*ifftshift(ifft(fftshift(u)));
FFT_Mc=fftshift(fft(ifftshift(u)));

%%%%%%%%%%
% STEP 3 %
%%%%%%%%%%

result=FFT_Mc(1+(c-1)*M/2:(c+1)*M/2)./phi;

end 
